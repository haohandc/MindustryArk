import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { readSaveMeta, SaveMeta } from './SaveLibrary';
import {
  isDir, pathExists, listFiles,
  newTreeStat, copyTreeInto, removeTree, TreeStat,
} from '../utils/FsTree';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

const WANTED: string[] = [
  'saves',            /* 存档 —— 核心 */
  'mods',             /* 模组 —— 与存档强相关（存档会记录它用了哪些 mod） */
  'maps',             /* 自定义地图 */
  'schematics',       /* 蓝图 */
  'settings.bin',     /* ⭐ 设置 + **存档显示名**都在这（见文件头） */
  'server_list.json', /* 收藏的服务器 */
];

/**
 * 给导出文件起名用的时间戳：`20261003-1745`。版本号 + 导出时间
 */
export function stampNow(): string {
  const d: Date = new Date();
  const two = (n: number): string => (n < 10 ? '0' + String(n) : String(n));
  return String(d.getFullYear()) + two(d.getMonth() + 1) + two(d.getDate())
       + '-' + two(d.getHours()) + two(d.getMinutes());
}

export const TMP_DIR_NAME: string = 'datapack';

export function ensureDir(path: string): boolean {
  if (pathExists(path)) {
    return true;
  }
  try {
    fs.mkdirSync(path, true);
  } catch (e) {
    /* 目录已存在也会走到这里 —— 交给下面那行确认，不要在这里下结论。 */
  }
  return pathExists(path);
}

/* 每复制4MB让出一帧给界面，避免UI线程占满。使用setTimeout(0)让出，不是taskpool。 */
const YIELD_EVERY_BYTES: number = 4 * 1024 * 1024;

function yieldToUi(): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => { resolve(); }, 0);
  });
}

/** 拷贝沙箱文件到沙箱路径，分块读写，async，调用方需await。 */
export async function copyLocalFile(srcPath: string, dstPath: string): Promise<string> {
  let out: fs.File | undefined = undefined;
  try {
    const inF: fs.File = fs.openSync(srcPath, fs.OpenMode.READ_ONLY);
    out = fs.openSync(dstPath, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      const buf: ArrayBuffer = new ArrayBuffer(64 * 1024);
      let sinceYield: number = 0;
      let n: number = fs.readSync(inF.fd, buf);
      while (n > 0) {
        fs.writeSync(out.fd, buf, { length: n });
        sinceYield += n;
        if (sinceYield >= YIELD_EVERY_BYTES) {
          sinceYield = 0;
          await yieldToUi();
        }
        n = fs.readSync(inF.fd, buf);
      }
    } finally {
      fs.closeSync(inF);
    }
    return '';
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'datapack: copying to %{public}s failed (%{public}s)',
               dstPath, err.message);
    return '写到导出位置失败：' + err.message;
  } finally {
    if (out !== undefined) {
      try { fs.closeSync(out); } catch (e) { /* 已经关了 */ }
    }
  }
}

/** 拷贝 picker URI 到沙箱（zlib 只能处理沙箱路径）。异步函数，需 await。 */
export async function readUriToFile(uri: string, dstPath: string): Promise<string> {
  let src: fs.File | undefined = undefined;
  try {
    src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const out: fs.File = fs.openSync(dstPath,
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      const buf: ArrayBuffer = new ArrayBuffer(64 * 1024);
      let sinceYield: number = 0;
      let n: number = fs.readSync(src.fd, buf);
      while (n > 0) {
        /*  **必须带 `length`**：不带的话会把整个 64KB 缓冲区写出去。 */
        fs.writeSync(out.fd, buf, { length: n });
        sinceYield += n;
        if (sinceYield >= YIELD_EVERY_BYTES) {
          sinceYield = 0;
          await yieldToUi();
        }
        n = fs.readSync(src.fd, buf);
      }
    } finally {
      fs.closeSync(out);
    }
    return '';
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'datapack: copying the picked uri failed (%{public}s)', err.message);
    return '读取选定文件失败：' + err.message;
  } finally {
    if (src !== undefined) {
      try { fs.closeSync(src); } catch (e) { /* 已经关了 */ }
    }
  }
}

/** 数据目录中实际存在且应被打包的内容。返回空数组时，调用方必须拒绝打包。 */
export function packableItems(dataDir: string): string[] {
  const out: string[] = [];
  for (const name of WANTED) {
    const p: string = dataDir + '/' + name;
    if (pathExists(p)) {
      out.push(p);
    }
  }
  return out;
}

/** 打包一个数据目录。返回 '' = 成功，否则失败原因。必须「先暂存、再压目录」，不能用 compressFiles。 */
export async function packDataDir(dataDir: string, tmpDir: string, outZip: string): Promise<string> {
  if (!isDir(dataDir)) {
    return '数据目录不存在：' + dataDir;
  }
  const items: string[] = packableItems(dataDir);
  if (items.length === 0) {
    return '这个版本没有任何可打包的数据（saves / mods / 地图 / 蓝图 全都不在）。';
  }
  if (!ensureDir(tmpDir)) {
    return '建不出临时目录：' + tmpDir;
  }
  /* 暂存目录必须与导入用的分开，避免冲突。 */
  const staging: string = tmpDir + '/packing';
  /* 每次重来，清除旧暂存/旧 zip。 */
  const accWipe: TreeStat = newTreeStat();
  removeTree(staging, 0, accWipe);
  if (!ensureDir(staging)) {
    return '建不出暂存目录：' + staging;
  }
  if (pathExists(outZip)) {
    try { fs.unlinkSync(outZip); } catch (e) { /* 删不掉则后续报错 */ }
  }

  /* ① 暂存：按原名拷贝，保持层级。 */
  const acc: TreeStat = newTreeStat();
  for (const src of items) {
    const name: string = src.substring(src.lastIndexOf('/') + 1);
    const dst: string = staging + '/' + name;
    if (isDir(src)) {
      copyTreeInto(src, dst, 0, acc);
    } else {
      try {
        fs.copyFileSync(src, dst);
        acc.files += 1;
      } catch (e) {
        acc.failed += 1;
        if (acc.firstError === '') {
          const err = e as BusinessError;
          acc.firstError = src + ' -> ' + dst + ': ' + err.message;
        }
      }
    }
  }
  if (acc.failed > 0) {
    hilog.error(DOMAIN, TAG, 'datapack: staging had %{public}d failure(s), first: %{public}s',
                acc.failed, acc.firstError);
    return '暂存失败（' + String(acc.failed) + ' 项）：' + acc.firstError;
  }

  try {
    /* 使用 BEST_SPEED：包内多数内容已压缩过。 */
    await zlib.compressFile(staging, outZip, {
      level: zlib.CompressLevel.COMPRESS_LEVEL_BEST_SPEED,
    });
    if (!pathExists(outZip)) {
      return '压缩没有产出文件。';
    }
    hilog.info(DOMAIN, TAG,
               'datapack: packed %{public}d dir(s) / %{public}d file(s) into %{public}s',
               acc.dirs, acc.files, outZip);
    /* 成功才清暂存。 */
    const accClean: TreeStat = newTreeStat();
    removeTree(staging, 0, accClean);
    return '';
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'datapack: compressFile failed (%{public}s, code=%{public}d)',
               err.message, err.code);
    return '压缩失败：' + err.message + ' (code=' + err.code + ')';
  }
}

/** 包内可打包项数量 */
export function countPackable(dataDir: string): string {
  const parts: string[] = [];
  for (const name of WANTED) {
    const p: string = dataDir + '/' + name;
    if (isDir(p)) {
      try {
        parts.push(name + ' ' + listFiles(p).length);
      } catch (e) {
        parts.push(name + ' ?');
      }
    } else if (pathExists(p)) {
      parts.push(name);
    }
  }
  return parts.join('  ');
}

/* ==========================================================================
 * 导入
 * ========================================================================== */

/** 解压到已存在目录（Zip Slip 由平台防御） */
export async function unpackZip(zipPath: string, stagingDir: string): Promise<string> {
  if (!pathExists(zipPath)) {
    return '找不到压缩包：' + zipPath;
  }
  if (!zipPath.endsWith('.zip')) {
    return '压缩包路径必须以 .zip 结尾。';
  }
  if (!ensureDir(stagingDir)) {
    return '无法建立解压目录：' + stagingDir;
  }
  try {
    await zlib.decompressFile(zipPath, stagingDir, {});
    return '';
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'datapack: decompressFile failed (%{public}s, code=%{public}d)',
               err.message, err.code);
    if (err.code === 900003) {
      return '这个文件不是 zip，或者已经损坏。';
    }
    return '解压失败：' + err.message + ' (code=' + err.code + ')';
  }
}

/** 判断目录是否为数据根（宽松判据） */
function looksLikeDataRoot(dir: string): boolean {
  return isDir(dir + '/saves') || isDir(dir + '/mods') || pathExists(dir + '/settings.bin');
}

/** 定位数据根（只探单一子目录，限深） */
export function locateDataRoot(dir: string, depth: number = 0): string {
  if (looksLikeDataRoot(dir)) {
    return dir;
  }
  if (depth > 4) {
    return '';
  }
  let children: string[] = [];
  try {
    children = listFiles(dir);
  } catch (e) {
    return '';
  }
  const dirs: string[] = [];
  for (const name of children) {
    if (isDir(dir + '/' + name)) {
      dirs.push(name);
    }
  }
  if (dirs.length !== 1) {
    return '';
  }
  return locateDataRoot(dir + '/' + dirs[0], depth + 1);
}

/** 校验候选数据根 */
export function validatePack(root: string): string {
  const savesDir: string = root + '/saves';
  if (!looksLikeDataRoot(root)) {
    return '这个包里没有 saves/、mods/ 或 settings.bin';
  }
  if (!isDir(savesDir)) {
    return '';
  }
  let files: string[] = [];
  try {
    files = listFiles(savesDir);
  } catch (e) {
    return '读不出 saves/ 目录。';
  }
  const msav: string[] = files.filter((n: string) => n.endsWith('.msav'));
  if (msav.length === 0) {
    return 'saves/ 里没有 .msav 文件。';
  }
  for (const name of msav) {
    const meta: SaveMeta = readSaveMeta(savesDir + '/' + name);
    if (meta.ok) {
      return '';
    }
  }
  return 'saves/ 里有 ' + String(msav.length) + ' 个 .msav，但没有一个能读出存档元数据';
}
