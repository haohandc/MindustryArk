/* 目录树的复制与删除 —— 只有这一份实现（版本隔离与存档回收站共用）。
 *
 * ⛔ 不用 `fs.copyDirSync`：2026-10-02 四用例二分（同一台平板）——
 *    `copyDirSync(空目录, 新路径)` 报 Invalid argument 13900020，而 `copyFileSync` 成功。
 *    ⭐ **连空目录都复制不了** ⇒ 不是内容、不是父目录、不是路径长度。不需要知道它为什么坏。
 * ⭐ 可用积木：`mkdirSync` / `listFileSync` / `statSync` / `copyFileSync`。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/* 环的保护：`statSync` 跟随符号链接，指向上级的链接会让递归不终止、把主线程钉死。 */
const MAX_DEPTH = 32;

/** 一次复制/删除的记账。
 *  `firstError` 保留原样（调用点的措辞依赖它），`samples` 额外多留几条 —— 理由见 `recordFailure`。 */
export interface TreeStat {
  dirs: number;
  files: number;
  failed: number;
  firstError: string;
  samples: string[];
}

/** 多留几条错误的上限。⛔ 只留第一条时，一次「整片失败」会看起来像「某一条失败」。 */
const SAMPLE_CAP = 8;

export function newTreeStat(): TreeStat {
  return { dirs: 0, files: 0, failed: 0, firstError: '', samples: [] };
}

/* 记一次失败。⭐ `firstError` 保留、额外收样本，两个理由：
 *  ① 调用点的措辞（`'复制没完成（N 个文件没复制过去）：' + acc.firstError`）都读 `firstError`
 *     ⇒ 动它要改好几处，不值当。
 *  ② ⭐⭐ **只留第一条会把「整片写不进去」报告成「某一条失败」的样子。** 2026-10-04 的真实教训：
 *     存储迁移在外置根上失败，屏幕上只有一条 `复制失败 <路径>：操作不被允许` ⇒
 *     看起来像某个文件有病，而实际是那一整片都写不进去。⇒ 多留几条，一眼能看出分布。 */
function recordFailure(acc: TreeStat, msg: string): void {
  acc.failed += 1;
  if (acc.firstError === '') {
    acc.firstError = msg;
  }
  if (acc.samples.length < SAMPLE_CAP) {
    acc.samples.push(msg);
  }
}

/** `accessSync` 不抛、只返回 boolean，这里包一层统一语义。 */
function exists(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (e) {
    return false;
  }
}

/* 递归复制，同步（实测 188 文件 120ms）。⚠️ 但它不该出现在渲染路径上。
 * ⚠️ 每层自己 `mkdir` ⇒ 调用方**不需要**预建父目录。 */
export function copyTreeInto(src: string, dst: string, depth: number, acc: TreeStat): void {
  if (depth > MAX_DEPTH) {
    recordFailure(acc, '目录层级超过 ' + String(MAX_DEPTH) + ' 层（可能有环）');
    return;
  }
  try {
    if (!exists(dst)) {
      fs.mkdirSync(dst, true);
    }
  } catch (e) {
    const err = e as BusinessError;
    recordFailure(acc, '建目录失败 ' + dst + '：' + err.message);
    return;
  }
  acc.dirs += 1;

  let names: string[] = [];
  try {
    names = fs.listFileSync(src);
  } catch (e) {
    const err = e as BusinessError;
    recordFailure(acc, '列目录失败 ' + src + '：' + err.message);
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
      recordFailure(acc, '读状态失败 ' + s + '：' + err.message);
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
        /* ⛔⛔ **一定要把 `d` 也打出来。** 原来只打源路径，而 `copyFileSync(s, d)` 有**两个** open：
         *     读 `s` 和写 `d`。EPERM（「操作不被允许」）在**读自己的沙箱文件**时几乎不可能出现，
         *     它出现在**往外部文件夹写**的时候 ⇒ 只打源路径会把人引到**错的那一侧**去查
         *     （2026-10-04 就是这样：我拿着一个沙箱路径分析了半天，而真正被拒的是外置那一侧）。 */
        recordFailure(acc, '复制失败 ' + s + ' → ' + d + '：' + err.message);
      }
    }
  }
}

/* 递归删除一棵树。⚠️ 到最后一层才 `rmdirSync`，那一刻里面已经空了。 */
export function removeTree(path: string, depth: number, acc: TreeStat): void {
  if (depth > MAX_DEPTH) {
    recordFailure(acc, '目录层级超过 ' + String(MAX_DEPTH) + ' 层（可能有环）');
    return;
  }
  if (!exists(path)) {
    return;
  }

  /* ⛔ 先判是不是目录 —— 它在**普通文件**上也必须能直接删。
   * 原来是缺这一段的，而对文件调 `listFileSync` 只报 `Not a directory`：
   * 隔离那边一直拿目录调它，所以「它删不了文件」从没暴露过，
   * 是回收站的端到端探针（合成数据）才抓到的。
   * ⇒ 它自己处理两种情况，⛔ 不靠调用方「记得只能传目录」。 */
  if (!isDir(path)) {
    try {
      fs.unlinkSync(path);
      acc.files += 1;
    } catch (e) {
      const err = e as BusinessError;
      recordFailure(acc, '删除失败 ' + path + '：' + err.message);
    }
    return;
  }

  let names: string[] = [];
  try {
    names = fs.listFileSync(path);
  } catch (e) {
    const err = e as BusinessError;
    recordFailure(acc, '列目录失败 ' + path + '：' + err.message);
    return;
  }
  for (const n of names) {
    const c: string = path + '/' + n;
    let isDir: boolean = false;
    try {
      isDir = fs.statSync(c).isDirectory();
    } catch (e) {
      recordFailure(acc, '读状态失败 ' + c);
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
        recordFailure(acc, '删除失败 ' + c + '：' + err.message);
      }
    }
  }
  try {
    fs.rmdirSync(path);
    acc.dirs += 1;
  } catch (e) {
    const err = e as BusinessError;
    recordFailure(acc, '删目录失败 ' + path + '：' + err.message);
  }
}

/** 一个目录下的名字（不递归）。列不出来时返回空数组，不抛。 */
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

/** 字节数；目录或读不到时 0。 */
export function sizeOf(path: string): number {
  try {
    const st: fs.Stat = fs.statSync(path);
    return st.isDirectory() ? 0 : st.size;
  } catch (e) {
    return 0;
  }
}

/** 是不是目录；读不到时 false。 */
export function isDir(path: string): boolean {
  try {
    return fs.statSync(path).isDirectory();
  } catch (e) {
    return false;
  }
}

/** 路径存在吗（给别的模块用）。 */
export function pathExists(path: string): boolean {
  return exists(path);
}
